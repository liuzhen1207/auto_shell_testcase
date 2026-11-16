#!/bin/bash
# 收尾：SEC-09(sep) → 切普通模式 → 普通模式全量
set -u
A=/data/iotdb/autotest
S=$A/sec_skill
L=$A/rc2_regression_logs
LOG=$L/sec_final_run.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

say "=== 1) SEC-09 复跑（三权分立）==="
( cd "$S" && bash tools/run_all.sh --set replica --mode sep ) >>"$LOG" 2>&1
say "  SEC-09: $(grep -a 'RESULT' "$S"/results/SEC-09_*_*.out 2>/dev/null | tail -1 | cut -c1-110)"

say "=== 2) 切回普通模式（写配置 false + 重启）==="
( cd "$S" && bash tools/mode_sep.sh off ) >>"$LOG" 2>&1
sleep 5
rootok=$(printf 'set sql_dialect=tree;\nshow databases;\n' | timeout 60 /data/iotdb/testdb/v20131rc2_1110_83183d0/sbin/start-cli.sh -h 192.168.99.77 -u root -pw 'TimechoDB@2021' 2>&1 | grep -cE 'root\.|Msg: The statement')
say "  root 登录可用性（>0 表示已回普通模式）: $rootok"

say "=== 3) 普通模式全量（9 条）==="
( cd "$S" && bash tools/run_all.sh --set all --mode normal ) >>"$LOG" 2>&1
say "  普通模式完成"
grep -a 'RESULT ' "$LOG" | tail -12 | cut -c1-140 | tee -a "$LOG"
say "final_done=$(date '+%F %T')"
