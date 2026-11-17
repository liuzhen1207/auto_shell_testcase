#!/bin/bash
# 对照 TDB-899 与"非授权 UNLOCK 305"：同一集群上跑权限矩阵
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
LOG=/data/iotdb/autotest/rc2_regression_logs/tdb899_vs_305.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-230; }
qok(){ printf 'set sql_dialect=tree;\nlist user;\n' | timeout 30 "$CLI" -h "$H" -u "$1" -pw "$2" 2>&1 | grep -acE "$3"; }

say "0) 当前模式判定"
root_out=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE '803|root' | head -1 | cut -c1-90)
say "  root: $root_out"
if printf '%s' "$root_out" | grep -q 803; then MODE=sep; else MODE=normal; fi
say "  判定模式: $MODE"

if [ "$MODE" = "normal" ]; then
  say "1) 用 root 热开三权分立"
  say "  $(q root "set configuration 'enable_separation_of_powers'='true';" "$P")"
  sleep 10
  MODE=sep
fi

say "2) security_admin 建普通用户 + 造一个锁（可选）"
say "  create: $(q security_admin "create user t899 'Abcdefgh123!';" "$P")"
say "  再确认 security_admin 可登录: $(qok security_admin "$P" 'security_admin')"

say "3) 权限矩阵（sep 模式）"
say "  3.1 security_admin 全局解锁      : $(q security_admin "alter user t899 account unlock;" "$P")"
say "  3.2 security_admin IP 级解锁     : $(q security_admin "alter user t899 @ '192.168.99.80' account unlock;" "$P")"
say "  3.3 sys_admin 全局解锁           : $(q sys_admin "alter user t899 account unlock;" "$P")"
say "  3.4 audit_admin 全局解锁         : $(q audit_admin "alter user t899 account unlock;" "$P")"
say "  3.5 普通用户(无权限) 全局解锁    : $(q t899 "alter user t899 account unlock;" 'Abcdefgh123!')"
say "  3.6 普通用户(无权限) IP 级解锁   : $(q t899 "alter user t899 @ '192.168.99.80' account unlock;" 'Abcdefgh123!')"
say "  3.7 对照：普通用户 CREATE USER   : $(q t899 "create user t899b 'Abcdefgh123!';" 'Abcdefgh123!')"

say "4) 日志取证（sep 下的 701 / NPE 分别出现几次）"
for h in 77; do
  say "  .$h Unsupported author type: $(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -ac 'Unsupported author type' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null)"
  say "  .$h Cannot read the array length: $(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -ac 'Cannot read the array length' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null)"
  say "  .$h INTERNAL_SERVER_ERROR(305): $(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -ac 'INTERNAL_SERVER_ERROR(305)' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null)"
done

say "5) 清理测试用户"
q security_admin "drop user t899;" "$P" >/dev/null
q security_admin "drop user t899b;" "$P" >/dev/null
say "done  (集群当前处于 $MODE 模式)"
