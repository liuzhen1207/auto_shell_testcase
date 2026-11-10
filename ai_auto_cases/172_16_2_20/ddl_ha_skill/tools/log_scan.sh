#!/bin/bash
# log_scan.sh <case_dir> <dn_list>
# 扫描各节点日志中的 ERROR/WARN；已知可接受模式单独归类
set -u
. "$(dirname "$0")/lib.sh"

CASE_DIR=$1; NODES=${2:-"$DNS $CNS"}
OUT=$CASE_DIR/log-scan.txt
LOG=$NEW/logs
: > "$OUT"

BENIGN='LeaderBalancer|CHANGE_REGION_LEADER|TransferLeader|INVALIDATE_LAST_CACHE|AppendLogResponseHandler|GrpcLogAppender|Leader has not been elected|PRE_VOTE|Failed to change the leader|recover compaction|some other task is operating|please retry|Failed to PIPE_HEARTBEAT|Failed to UPDATE_TABLE|Failed to (CREATE|DELETE|ALTER|INVALIDATE)[A-Z_]* on DataNode|DataNodeTSStatusRPCHandler|PipeHeartbeatRPCHandler|Failed to .* on DataNode'

total_err=0; suspect=0
for n in $NODES; do
  for f in log_datanode_all.log log_confignode_all.log; do
    body=$(ssh -n -o BatchMode=yes root@"$(ip_of "$n")" "tail -n 4000 $LOG/$f 2>/dev/null" 2>/dev/null)
    [ -z "$body" ] && continue
    errs=$(printf '%s\n' "$body" | grep -c ' ERROR ' || true)
    [ "$errs" -eq 0 ] && continue
    total_err=$((total_err + errs))
    bad=$(printf '%s\n' "$body" | grep ' ERROR ' | grep -vE "$BENIGN" | sed -E 's/^[0-9-]+ [0-9:,]+ \[[^]]*\] ERROR +//' | cut -c1-160 | sort | uniq -c | sort -rn | head -n 3)
    nb=$(printf '%s\n' "$bad" | grep -c '[0-9]' || true)
    echo "== node$n $f: ERROR=$errs 非白名单类=$nb" >> "$OUT"
    [ -n "$bad" ] && printf '%s\n' "$bad" | sed 's/^/    /' >> "$OUT"
    suspect=$((suspect + nb))
  done
done

echo "LOG_TOTAL_ERROR=$total_err LOG_SUSPECT=$suspect" >> "$OUT"
if [ "$suspect" -eq 0 ]; then echo "LOG_SCAN=OK" >> "$OUT"; else echo "LOG_SCAN=SUSPECT" >> "$OUT"; fi

# 隔离/租约相关证据（P 组用）
if grep -qiE 'lease|fence|isolation|isolat' "$OUT" 2>/dev/null; then echo "LOG_ISOLATION_HINT=YES" >> "$OUT"; else echo "LOG_ISOLATION_HINT=NO" >> "$OUT"; fi
