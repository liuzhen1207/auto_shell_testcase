#!/bin/bash
# ============================================================================
# 逐用例 CN/DN 日志窗口检查（releasenote_skill）
#   log_mark            记录 3 CN + 5 DN 的 error/warn 日志当前行号
#   log_check [id]      扫描窗口内新增行，过滤已知噪声，输出 "err=N warn=M unexp=K"
#   RN_LOG_CHECK=1 时由 suite_rn.sh 自动调用；unexp>0 视为用例失败
# 日志位置：
#   CN: /data/iotdb/$NEW/logs/log_confignode_{error,warn}.log
#   DN: /data1/iotdb/$NEW/logs/log_datanode_{error,warn}.log
# ============================================================================
LOGMARK_DIR=${LOGMARK_DIR:-/tmp/rn_logmark}
RN_NOISE_RE='Connection refused|Connection reset|Socket is closed by peer|Broken pipe|Cannot assign requested address|leader may have been down|CHANGE_REGION_LEADER|UPDATE_REGION_ROUTE_MAP|UPDATE_TABLE|INVALIDATE_LAST_CACHE|RouteBalancer|RaftServerImpl|GrpcLogAppender|requestVote|appendEntries|Timeout during|DataNodeTSStatusRPCHandler|AbstractAlterOrDropTableProcedure|processing openSession|Schedule task failed|ShutdownHook|Fail to start server|Cannot pull system configurations|dispatch write failed|TIMESERIES_ALREADY_EXIST|Template .* does not exist|Failed to FLUSH|read-only|is fenced|PIPE_HEARTBEAT|PIPE_PUSH_ALL_META|PIPE_PUSH_META'

_rn_log_offsets() {  # $1=ip $2=kind(cn|dn) -> "err warn"
  local dir=/data/iotdb
  [ "$2" = "dn" ] && dir=/data1/iotdb
  ssh -n -o StrictHostKeyChecking=no root@$1 "wc -l < $dir/${LOG_NEW:-$NEW}/logs/log_${2}_error.log 2>/dev/null || echo 0; wc -l < $dir/${LOG_NEW:-$NEW}/logs/log_${2}_warn.log 2>/dev/null || echo 0" 2>/dev/null | tr -d ' '
}

log_mark() {
  rm -rf "$LOGMARK_DIR"; mkdir -p "$LOGMARK_DIR"
  local ip kind vals
  for ip in $CN_LIST; do
    vals=$(_rn_log_offsets "$ip" cn); echo "${vals}" > "$LOGMARK_DIR/cn_$ip"
  done
  for ip in $DN_LIST; do
    vals=$(_rn_log_offsets "$ip" dn); echo "${vals}" > "$LOGMARK_DIR/dn_$ip"
  done
}

log_check() {  # $1=可选 case id（用于样本文件名）
  local id="${1:-case}" e w ip kind dir out line total_e=0 total_w=0 unexp=0 samples="/tmp/rn_logcheck_${id}.txt"
  : > "$samples"
  for f in "$LOGMARK_DIR"/cn_* "$LOGMARK_DIR"/dn_*; do
    [ -f "$f" ] || continue
    local base; base=$(basename "$f")
    kind=${base%%_*}; ip=${base#*_}
    read -r e w <<< "$(cat "$f")"
    dir=/data/iotdb; [ "$kind" = "dn" ] && dir=/data1/iotdb
    out=$(ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((${e:-0} + 1)) $dir/${LOG_NEW:-$NEW}/logs/log_${kind}_error.log 2>/dev/null; tail -n +$((${w:-0} + 1)) $dir/${LOG_NEW:-$NEW}/logs/log_${kind}_warn.log 2>/dev/null" 2>/dev/null)
    [ -z "${out:-}" ] && continue
    while IFS= read -r line; do
      case "$line" in
        *" ERROR "*) total_e=$((total_e+1)) ;;
        *" WARN "*)  total_w=$((total_w+1)) ;;
        *) continue ;;
      esac
      if echo "$line" | grep -qE "$RN_NOISE_RE"; then continue; fi
      unexp=$((unexp+1))
      echo "[$kind $ip] $line" >> "$samples"
    done <<< "$out"
  done
  echo "err=$total_e warn=$total_w unexp=$unexp"
}
