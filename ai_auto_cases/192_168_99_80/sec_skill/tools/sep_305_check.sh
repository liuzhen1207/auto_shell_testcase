#!/bin/bash
# 三权分立模式下的 UNLOCK 权限矩阵 + 305/NPE 日志增量核对
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
LOG=/data/iotdb/autotest/rc2_regression_logs/sep_305_check.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-200; }
cntnpe(){ ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -ac 'Cannot read the array length' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
cnt305(){ ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -ac 'INTERNAL_SERVER_ERROR(305)' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
cnt701(){ ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -ac 'Unsupported author type' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }

say "0) 确认当前是三权分立"
rootcode=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aoE '803' | head -1)
say "  root 登录返回 803? [${rootcode:-否}]  → 三权分立=$([ -n "$rootcode" ] && echo yes || echo no)"

b_npe=$(cntnpe); b_305=$(cnt305); b_701=$(cnt701)
say "1) 基线日志计数：NPE=$b_npe  305=$b_305  701=$b_701"

say "2) 准备用户"
q security_admin "drop user s305;" "$P" >/dev/null
q security_admin "drop user s305sec;" "$P" >/dev/null
say "   create s305   : $(q security_admin "create user s305 'Abcdefgh123!';" "$P")"
say "   create s305sec: $(q security_admin "create user s305sec 'Abcdefgh123!';" "$P")"
say "   grant security: $(q security_admin "grant security on root.** to user s305sec;" "$P")"

say "3) 矩阵（三权分立）"
say "  3.1 security_admin 全局解锁      : $(q security_admin "alter user s305 account unlock;" "$P")"
say "  3.2 security_admin IP 级解锁     : $(q security_admin "alter user s305 @ '192.168.99.80' account unlock;" "$P")"
say "  3.3 security_admin 解锁不存在用户: $(q security_admin "alter user nouser_x account unlock;" "$P")"
say "  3.4 sys_admin 全局解锁           : $(q sys_admin "alter user s305 account unlock;" "$P")"
say "  3.5 audit_admin 全局解锁         : $(q audit_admin "alter user s305 account unlock;" "$P")"
say "  3.6 普通用户 全局解锁            : $(q s305 "alter user s305 account unlock;" 'Abcdefgh123!')"
say "  3.7 普通用户 IP 级解锁           : $(q s305 "alter user s305 @ '192.168.99.80' account unlock;" 'Abcdefgh123!')"
say "  3.8 普通用户 解锁 root           : $(q s305 "alter user root account unlock;" 'Abcdefgh123!')"
say "  3.9 有 SECURITY 的普通用户 解锁  : $(q s305sec "alter user s305 account unlock;" 'Abcdefgh123!')"
say "  3.10 有 SECURITY 的普通用户 IP 级: $(q s305sec "alter user s305 @ '192.168.99.80' account unlock;" 'Abcdefgh123!')"

say "4) 增量核对（应与基线相同：无新增 305/NPE）"
a_npe=$(cntnpe); a_305=$(cnt305); a_701=$(cnt701)
say "   结束计数：NPE=$a_npe(+$((a_npe-b_npe)))  305=$a_305(+$((a_305-b_305)))  701=$a_701(+$((a_701-b_701)))"
if [ "$a_npe" -eq "$b_npe" ] && [ "$a_305" -eq "$b_305" ]; then
  say "   ✅ 三权分立下未产生新的 NPE / 305"
else
  say "   ❌ 三权分立下出现新增 NPE/305，需进一步分析"
fi

say "5) 清理"
q security_admin "drop user s305;" "$P" >/dev/null
q security_admin "drop user s305sec;" "$P" >/dev/null
say "done"
