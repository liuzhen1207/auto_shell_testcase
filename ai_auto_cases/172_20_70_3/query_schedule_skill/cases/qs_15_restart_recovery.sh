#!/bin/bash
# QS-15 重启恢复：DN 重启后调度与查询恢复正常
#   覆盖需求：REQ-16（调度器生命周期与查询引擎一致，重启后恢复）
#   判据：① 重启 1 个 DN 后集群恢复 8/8；② 重启后查询正常；③ SHOW QUERIES 可用（调度器已起来）
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-15
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
DEVS=$(qs_ensure_data)
assert_ge "①数据已就绪" "${DEVS:-0}" 100

H="${DN[0]}"
log "=== 重启 DataNode ${H} ==="
sshx "$H" "sudo $DB_DIR/sbin/stop-datanode.sh" >/dev/null 2>&1
sleep 10
sshx "$H" "sudo setsid nohup $DB_DIR/sbin/start-datanode.sh </dev/null >/tmp/qs15_dn.start 2>&1 &" >/dev/null 2>&1
for i in $(seq 1 30); do
  sleep 10
  n=$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')
  log "  [${i}0s] Running+ACTIVATED=${n}"
  [ "${n:-0}" -ge 8 ] && break
done
assert_eq "②重启后集群恢复 8/8" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"

RS=$(sq "select count(*) from $QS_LONG_DB.**;" 2>/dev/null | grep -cE '^\|')
assert_ge "③重启后查询正常" "${RS:-0}" 1
sq "show queries;" >/dev/null 2>&1 && pass "④SHOW QUERIES 可用（调度器已恢复，REQ-16）" || fail "④SHOW QUERIES 不可用"
write_result 2>/dev/null || true

