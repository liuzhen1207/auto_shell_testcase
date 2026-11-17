#!/bin/bash
# 验证 TDB-899 是否在 RC2 修复：sep 模式下真锁定 → security_admin 解锁 → 能否登录
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
LOG=/data/iotdb/autotest/rc2_regression_logs/tdb899_fixed_check.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
code(){ printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h "$H" -u "$1" -pw "$2" 2>&1 | grep -aoE '[0-9]{3}:' | head -1 | tr -d ':'; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-200; }

say "0) 模式：$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -ac 803) (1=sep)"
say "1) security_admin 建用户 lock899"
q security_admin "drop user lock899;" "$P" >/dev/null
say "   create: $(q security_admin "create user lock899 'Abcdefgh123!';" "$P")"
say "2) 连续错误密码（默认阈值 5，第 6 次应为 822）"
for i in 1 2 3 4 5 6; do
  say "   第 $i 次 → $(code lock899 'DefinitelyWrong123!')"
done
say "3) security_admin 全局解锁（TDB-899 场景）"
say "   unlock: $(q security_admin "alter user lock899 account unlock;" "$P")"
say "4) 解锁后登录"
say "   正确密码 code=$(code lock899 'Abcdefgh123!')  （空=无错误码=登录成功）"
say "5) 再锁一次 → IP 级解锁"
for i in 1 2 3 4 5 6; do code lock899 'DefinitelyWrong123!' >/dev/null; done
say "   锁定后 code=$(code lock899 'Abcdefgh123!')"
say "   unlock ip: $(q security_admin "alter user lock899 @ '192.168.99.80' account unlock;" "$P")"
say "   解锁后 code=$(code lock899 'Abcdefgh123!')"
say "6) 清理"
q security_admin "drop user lock899;" "$P" >/dev/null
say "7) 日志关键字（本次运行前后）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -ac 'Unsupported author type' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | sed 's/^/   Unsupported author type: /' | tee -a "$LOG"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -aE 'Cannot read the array length' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null | tail -4 | cut -c1-40" 2>/dev/null | sed 's/^/   NPE 时间戳: /' | tee -a "$LOG"
say "done"
